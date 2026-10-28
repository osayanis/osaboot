import Foundation

// Lance les outils de macOS (diskutil, hdiutil…) et lit leurs réponses.
enum Shell {
    struct Result { let status: Int32; let out: String; let err: String }

    /// `onLine` reçoit chaque ligne de la sortie au fil de l'eau (les « \r » des barres de
    /// progression comptent comme des fins de ligne).
    @discardableResult
    static func run(_ tool: String, _ args: [String], onLine: ((String) -> Void)? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var outData = Data(), errData = Data(), pending = Data()
        let lock = NSLock()
        func emit(_ d: Data, final: Bool) {
            guard let onLine else { return }
            pending.append(d)
            while let i = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...i)
                if !line.isEmpty { onLine(line) }
            }
            if final, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); outData.append(d); emit(d, final: false); lock.unlock()
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); errData.append(d); emit(d, final: false); lock.unlock()
        }
        try p.run()
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let restOut = out.fileHandleForReading.readDataToEndOfFile(), restErr = err.fileHandleForReading.readDataToEndOfFile()
        outData.append(restOut); errData.append(restErr)
        emit(restOut + restErr, final: true)
        lock.unlock()
        return Result(status: p.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    /// Réponse « -plist » d'un outil, en dictionnaire.
    static func plist(_ tool: String, _ args: [String]) throws -> [String: Any] {
        let r = try run(tool, args)
        guard r.status == 0, let d = try PropertyListSerialization.propertyList(from: Data(r.out.utf8), format: nil) as? [String: Any] else {
            throw Fail("\((tool as NSString).lastPathComponent) a échoué : \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return d
    }

    /// Même commande, mais avec le mot de passe administrateur demandé par macOS (fenêtre système).
    /// Les arguments ne viennent que de l'app (chemins de disque vérifiés), jamais de l'utilisateur.
    static func runAsAdmin(_ tool: String, _ args: [String]) throws -> Result {
        let cmd = ([tool] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        return try run("/usr/bin/osascript", ["-e", script])
    }
}

struct Fail: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
