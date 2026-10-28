import Foundation
import Combine

// Fait le lien entre le moteur (fil d'arrière-plan) et l'interface : étape, pourcentage,
// vitesse et temps restant, publiés au plus 10 fois par seconde.
final class Flasher: ObservableObject {
    enum Phase: Equatable { case idle, running, done(String), failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stage = ""
    @Published private(set) var fraction = 0.0
    @Published private(set) var speed = 0.0            // octets par seconde
    @Published private(set) var remaining: TimeInterval?

    var running: Bool { phase == .running }
    private var engine: Engine?
    private var activity: NSObjectProtocol?
    private var mark: (stage: String, time: Date, done: Int64)?
    private var lastPublish = Date.distantPast

    func start(image: SourceImage, drive: Drive, options: FlashOptions) {
        guard !running else { return }
        let e = Engine(image: image, drive: drive, options: options)
        e.onReport = { [weak self] r in DispatchQueue.main.async { self?.update(r) } }
        engine = e
        stage = "Préparation"; fraction = 0; speed = 0; remaining = nil; mark = nil
        phase = .running
        // pas de mise en veille pendant l'écriture
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Écriture d'une clé USB")
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Phase
            do { result = .done(try e.run()) }
            catch { result = e.cancelled ? .failed("Écriture annulée. La clé est sans doute inutilisable telle quelle : relance un flash ou formate-la.") : .failed(error.localizedDescription) }
            DispatchQueue.main.async {
                if let a = self.activity { ProcessInfo.processInfo.endActivity(a) }
                self.activity = nil
                self.engine = nil
                if case .done = result { self.fraction = 1 }
                self.phase = result
            }
        }
    }

    func cancel() { engine?.cancel() }

    /// Captures d'écran (OSABOOT_PREVIEW) : un état figé, sans rien écrire.
    func preview(_ p: Phase, stage: String = "Copie des fichiers", fraction: Double = 0.62) {
        self.stage = stage; self.fraction = fraction; speed = 31_400_000; remaining = 95
        phase = p
    }
    func reset() { if !running { phase = .idle } }

    private func update(_ r: Report) {
        let now = Date()
        let changed = r.stage != stage
        guard changed || now.timeIntervalSince(lastPublish) > 0.1 || r.done >= r.total else { return }
        lastPublish = now
        if changed { stage = r.stage; mark = nil; speed = 0; remaining = nil }
        fraction = r.total > 0 ? min(1, Double(r.done) / Double(r.total)) : 0
        // vitesse lissée, remise à zéro à chaque étape
        if let m = mark, m.stage == r.stage {
            let dt = now.timeIntervalSince(m.time)
            if dt >= 0.5 {
                let v = Double(r.done - m.done) / dt
                speed = speed == 0 ? v : speed * 0.7 + v * 0.3
                remaining = speed > 0 ? Double(r.total - r.done) / speed : nil
                mark = (r.stage, now, r.done)
            }
        } else {
            mark = (r.stage, now, r.done)
        }
    }
}
