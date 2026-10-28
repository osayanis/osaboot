import Foundation
import Darwin

// Ouvre /dev/rdiskN en lecture-écriture. Un utilisateur normal n'en a pas le droit : on passe
// par authopen, l'outil de macOS qui demande le mot de passe administrateur dans une fenêtre
// système puis nous transmet le descripteur de fichier, sans que l'app tourne en root.
enum RawDisk {
    static func open(_ path: String) throws -> Int32 {
        let fd = Darwin.open(path, O_RDWR)
        if fd >= 0 { return fd }
        guard errno == EACCES || errno == EPERM else { throw Fail("Impossible d'ouvrir la clé (\(String(cString: strerror(errno)))).") }
        return try viaAuthopen(path)
    }

    private static func viaAuthopen(_ path: String) throws -> Int32 {
        var sv: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else { throw Fail("socketpair a échoué.") }
        defer { Darwin.close(sv[0]) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        p.arguments = ["-stdoutpipe", "-o", String(O_RDWR), path]
        p.standardOutput = FileHandle(fileDescriptor: sv[1], closeOnDealloc: false)
        try p.run()
        Darwin.close(sv[1])

        // authopen envoie le descripteur dans un message de contrôle SCM_RIGHTS.
        var fd: Int32 = -1
        var byte: UInt8 = 0
        let hdr = MemoryLayout<cmsghdr>.size                 // 12 sur Darwin, aligné sur 4
        let space = hdr + MemoryLayout<Int32>.size
        let control = UnsafeMutableRawPointer.allocate(byteCount: space, alignment: 4)
        defer { control.deallocate() }
        while fd < 0 {
            memset(control, 0, space)
            let n: Int = withUnsafeMutablePointer(to: &byte) { b in
                var iov = iovec(iov_base: b, iov_len: 1)
                return withUnsafeMutablePointer(to: &iov) { iovp in
                    var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                                     msg_control: control, msg_controllen: socklen_t(space), msg_flags: 0)
                    return recvmsg(sv[0], &msg, 0)
                }
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            let c = control.assumingMemoryBound(to: cmsghdr.self).pointee
            if c.cmsg_level == SOL_SOCKET && c.cmsg_type == SCM_RIGHTS {
                fd = control.load(fromByteOffset: hdr, as: Int32.self)
            }
        }
        p.waitUntilExit()
        guard fd >= 0 else {
            throw Fail(p.terminationStatus == 0 ? "macOS n'a pas donné accès à la clé." : "Accès à la clé refusé (mot de passe annulé ?).")
        }
        return fd
    }
}
