import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

enum Theme {
    static let bg = Color(red: 0.05, green: 0.045, blue: 0.07)
    static let card = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.1)
    static let accent = Color(red: 0.53, green: 0.94, blue: 0.67)
    static let pink = Color(red: 0.96, green: 0.45, blue: 0.71)
    static let dim = Color.white.opacity(0.55)
    static func title(_ s: CGFloat) -> Font { .system(size: s, weight: .heavy, design: .rounded) }
}

// L'état de l'app : l'image, la clé, les options.
final class AppModel: ObservableObject {
    @Published var image: SourceImage?
    @Published var inspecting = false
    @Published var imageError: String?
    @Published var drive: Drive?
    @Published var options = FlashOptions()
    @Published var picking = false
    let drives = DriveList()
    let flasher = Flasher()
    private var bag = Set<AnyCancellable>()

    init() {
        // la clé choisie a disparu ? on l'oublie. Une seule clé branchée ? on la choisit.
        drives.$drives.sink { [weak self] list in
            guard let self, !self.flasher.running else { return }
            if let d = self.drive, !list.contains(d) { self.drive = list.first { $0.id == d.id && $0.size == d.size } }
            if self.drive == nil, list.count == 1, list[0].writable, !list[0].large { self.drive = list[0] }
        }.store(in: &bag)
    }

    func pickImage() {
        let p = NSOpenPanel()
        p.allowedContentTypes = SourceImage.extensions.compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = false
        p.message = "Choisis une image disque (.iso, .img)"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url { open(url) }
    }

    func open(_ url: URL) {
        guard !flasher.running else { return }
        inspecting = true
        imageError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try SourceImage.inspect(url) }
            DispatchQueue.main.async {
                self.inspecting = false
                switch r {
                case .success(let img): self.image = img
                case .failure(let e): self.image = nil; self.imageError = e.localizedDescription
                }
            }
        }
    }

    var canFlash: Bool {
        guard let image, let drive, drive.writable, !flasher.running else { return false }
        return drive.size >= image.needed
    }

    func flash() {
        guard canFlash, let image, let drive else { return }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = "Effacer « \(drive.name) » (\(drive.size.bytes)) ?"
        var info = "Tout ce qu'elle contient sera définitivement effacé"
        info += drive.volumes.isEmpty ? "." : " : \(drive.volumes.joined(separator: ", "))."
        if drive.large { info += "\n\nAttention : ce disque fait plus de 128 Go. Vérifie bien que ce n'est pas un disque de sauvegarde." }
        a.informativeText = info
        a.addButton(withTitle: "Effacer et flasher")
        a.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        flasher.start(image: image, drive: drive, options: options)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var flasher: Flasher
    @State private var dropping = false

    var body: some View {
        ZStack {
            Theme.bg
            Circle()
                .fill(RadialGradient(colors: [halo.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 300))
                .frame(width: 640, height: 640).offset(y: -300).blur(radius: 30)
                .animation(.easeInOut(duration: 0.8), value: flasher.phase)
            Group {
                switch flasher.phase {
                case .idle: SetupView(model: model, drives: model.drives)
                case .running: WorkingView(flasher: flasher, model: model)
                case .done(let msg): EndView(happy: true, title: "C'est prêt !", message: msg) { flasher.reset() }
                case .failed(let msg): EndView(happy: false, title: "Ça n'a pas marché", message: msg) { flasher.reset() }
                }
            }
            .padding(.horizontal, 36).padding(.top, 58).padding(.bottom, 26)
            if dropping {
                RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(12).allowsHitTesting(false)
            }
        }
        .frame(width: 780, height: 560)
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard !flasher.running, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { model.open(url) } } }
            return true
        }
    }

    private var halo: Color {
        switch flasher.phase {
        case .failed: return Theme.pink
        case .done: return Theme.accent
        default: return Color(red: 0.45, green: 0.55, blue: 1)
        }
    }
}

// MARK: - Choix de l'image et de la clé

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drives: DriveList

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Mascot(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OsaBoot").font(Theme.title(26))
                    Text("Une image, une clé, et c'est parti. Même pour Windows.").font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
                Spacer()
            }
            Spacer(minLength: 22)
            HStack(alignment: .top, spacing: 10) {
                StepCard(number: 1, icon: "opticaldisc", title: imageTitle, detail: imageDetail, badge: imageBadge,
                         action: model.inspecting ? nil : ("Choisir une image", model.pickImage), done: model.image != nil)
                chevron
                StepCard(number: 2, icon: "externaldrive", title: driveTitle, detail: driveDetail, badge: driveBadge,
                         action: (model.drive == nil ? "Choisir la clé" : "Changer", { model.picking = true }), done: model.drive != nil)
                chevron
                FlashCard(enabled: model.canFlash, hint: flashHint) { model.flash() }
            }
            Spacer(minLength: 18)
            options.frame(minHeight: 64, alignment: .top)
        }
        .sheet(isPresented: $model.picking) { DrivePicker(model: model, drives: drives) }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 16, weight: .bold)).foregroundStyle(.white.opacity(0.25)).padding(.top, 92)
    }

    // image
    private var imageTitle: String {
        if model.inspecting { return "Lecture de l'image…" }
        return model.image?.name ?? "Image"
    }
    private var imageDetail: String {
        if let e = model.imageError { return e }
        guard let img = model.image else { return "Glisse une .iso ou une .img ici, ou choisis-la." }
        switch img.kind {
        case .windows(let w): return "\(w.label) · \(img.size.bytes)"
        case .raw(let bootable): return bootable ? "\(img.size.bytes) · copiée telle quelle" : "\(img.size.bytes) · aucune table de partitions trouvée : elle risque de ne pas démarrer."
        }
    }
    private var imageBadge: (String, Color)? {
        guard let img = model.image else { return model.imageError != nil ? ("Illisible", Theme.pink) : nil }
        if case .windows(let w) = img.kind { return ("Windows \(w.arch)", Color(red: 0.45, green: 0.7, blue: 1)) }
        if case .raw(false) = img.kind { return ("À vérifier", Color.orange) }
        return ("Prête à copier", Theme.accent)
    }

    // clé
    private var driveTitle: String { model.drive?.name ?? "Clé USB" }
    private var driveDetail: String {
        guard let d = model.drive else {
            return drives.drives.isEmpty ? "Branche une clé USB." : "\(drives.drives.count) disque\(drives.drives.count > 1 ? "s" : "") externe\(drives.drives.count > 1 ? "s" : "") branché\(drives.drives.count > 1 ? "s" : "")."
        }
        return ([d.size.bytes] + (d.volumes.isEmpty ? [] : [d.volumes.joined(separator: ", ")])).joined(separator: " · ")
    }
    private var driveBadge: (String, Color)? {
        guard let d = model.drive else { return nil }
        if !d.writable { return ("Protégée en écriture", Theme.pink) }
        if let img = model.image, d.size < img.needed { return ("Trop petite", Theme.pink) }
        if d.large { return ("Grand disque", .orange) }
        return (d.virtual ? "Image (test)" : d.bus, Theme.accent)
    }

    private var flashHint: String {
        if model.image == nil { return "Choisis d'abord une image." }
        if model.drive == nil { return "Puis la clé à effacer." }
        if let img = model.image, let d = model.drive, d.size < img.needed { return "Il faut au moins \(img.needed.bytes)." }
        if model.image?.isWindows == true { return "Formatage en FAT32, puis copie de Windows." }
        return model.options.verify ? "Écriture puis vérification." : "Écriture sans vérification."
    }

    @ViewBuilder private var options: some View {
        if let img = model.image, case .windows(let w) = img.kind {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.options.bypassChecks) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Windows 11 sur un PC sans TPM 2.0 ni Secure Boot").font(.system(size: 13, weight: .semibold))
                        Text("L'installateur saute ses vérifications de matériel (TPM, Secure Boot, 4 Go de RAM).").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    }
                }
                .toggleStyle(RightSwitch())
                if w.needsSplit {
                    Label(Tools.wimlib() == nil
                          ? "\(w.install) fait \(w.installSize.bytes) : il faut wimlib pour le découper (introuvable)."
                          : "\(w.install) fait \(w.installSize.bytes) : il sera découpé en morceaux de 3,8 Go pour tenir en FAT32.",
                          systemImage: Tools.wimlib() == nil ? "exclamationmark.triangle.fill" : "scissors")
                        .font(.system(size: 12)).foregroundStyle(Tools.wimlib() == nil ? Theme.pink : Theme.dim)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        } else if model.image != nil {
            Toggle(isOn: $model.options.verify) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Vérifier la clé après l'écriture").font(.system(size: 13, weight: .semibold))
                    Text("Relit toute la clé et compare son empreinte SHA-256 à celle de l'image.").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                }
            }
            .toggleStyle(RightSwitch())
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct StepCard: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String
    let badge: (String, Color)?
    let action: (String, () -> Void)?
    let done: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon).font(.system(size: 34, weight: .medium))
                    .frame(width: 70, height: 70)
                    .background(Circle().fill(done ? Theme.accent.opacity(0.18) : Color.white.opacity(0.07)))
                    .foregroundStyle(done ? Theme.accent : .white.opacity(0.8))
                Text("\(number)").font(.system(size: 12, weight: .heavy, design: .rounded))
                    .frame(width: 22, height: 22).background(Circle().fill(done ? Theme.accent : Color.white.opacity(0.2)))
                    .foregroundStyle(done ? .black : .white).offset(x: 4, y: -2)
            }
            Text(title).font(.system(size: 15, weight: .bold)).lineLimit(1).truncationMode(.middle)
            if let badge {
                Text(badge.0).font(.system(size: 11, weight: .bold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(badge.1.opacity(0.2), in: Capsule()).foregroundStyle(badge.1)
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action: action.1) { Text(action.0).frame(maxWidth: .infinity) }
                    .buttonStyle(PillButton(filled: false))
            }
        }
        .padding(16)
        .frame(width: 200, height: 260)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(done ? Theme.accent.opacity(0.35) : Theme.line))
    }
}

struct FlashCard: View {
    let enabled: Bool
    let hint: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.fill").font(.system(size: 34))
                .frame(width: 70, height: 70)
                .background(Circle().fill(enabled ? Theme.pink.opacity(0.22) : Color.white.opacity(0.07)))
                .foregroundStyle(enabled ? Theme.pink : .white.opacity(0.35))
            Text("Flasher").font(.system(size: 15, weight: .bold))
            Text(hint).font(.system(size: 12)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: action) { Text("Flasher !").frame(maxWidth: .infinity) }
                .buttonStyle(PillButton(filled: true)).disabled(!enabled)
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(16)
        .frame(width: 200, height: 260)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
    }
}

struct RightSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            configuration.label
            Spacer(minLength: 0)
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
        }
    }
}

struct PillButton: ButtonStyle {
    var filled: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .padding(.vertical, 9).padding(.horizontal, 14)
            .background(Capsule().fill(filled ? (enabled ? Theme.pink : Color.white.opacity(0.08)) : Color.white.opacity(configuration.isPressed ? 0.18 : 0.1)))
            .foregroundStyle(filled ? (enabled ? Color.black : Color.white.opacity(0.35)) : .white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Choix de la clé

struct DrivePicker: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drives: DriveList
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sur quelle clé ?").font(Theme.title(20))
            Text("Seuls les disques externes sont proposés. Le disque de ton Mac n'apparaît jamais ici.")
                .font(.system(size: 12)).foregroundStyle(Theme.dim)
            if drives.drives.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 30)).foregroundStyle(Theme.dim)
                    Text("Aucune clé branchée pour l'instant.").font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(drives.drives) { d in row(d) }
                    }
                }
                .frame(maxHeight: 240)
            }
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.buttonStyle(PillButton(filled: false)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.bg)
        .foregroundStyle(.white)
    }

    private func row(_ d: Drive) -> some View {
        let tooSmall = model.image.map { d.size < $0.needed } ?? false
        let ok = d.writable && !tooSmall
        return Button {
            guard ok else { return }
            model.drive = d
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: d.virtual ? "opticaldisc" : "externaldrive.fill").font(.system(size: 22)).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.system(size: 14, weight: .bold))
                    Text(([d.size.bytes, d.bus] + d.volumes).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
                if !d.writable { tag("Protégée", Theme.pink) }
                else if tooSmall { tag("Trop petite", Theme.pink) }
                else if d.large { tag("Grand disque", .orange) }
                if model.drive == d { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            .padding(12)
            .background(model.drive == d ? Theme.accent.opacity(0.12) : Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .opacity(ok ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 10, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(c.opacity(0.2), in: Capsule()).foregroundStyle(c)
    }
}

// MARK: - Écriture en cours

struct WorkingView: View {
    @ObservedObject var flasher: Flasher
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Mascot(mood: .busy, size: 84)
            VStack(spacing: 6) {
                Text(flasher.stage).font(Theme.title(22))
                Text("\(model.image?.name ?? "") → \(model.drive?.name ?? "")").font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
            }
            VStack(spacing: 8) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(LinearGradient(colors: [Theme.accent, Color(red: 0.45, green: 0.7, blue: 1)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(14, g.size.width * flasher.fraction))
                            .animation(.easeOut(duration: 0.25), value: flasher.fraction)
                    }
                }
                .frame(height: 14)
                HStack {
                    Text("\(Int(flasher.fraction * 100)) %").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    Spacer()
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.dim).monospacedDigit()
                }
            }
            .frame(width: 480)
            Spacer()
            Button("Annuler") { flasher.cancel() }.buttonStyle(PillButton(filled: false))
            Text("Ne débranche pas la clé.").font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
    }

    private var detail: String {
        var parts: [String] = []
        if flasher.speed > 0 { parts.append("\(Int64(flasher.speed).bytes)/s") }
        if let r = flasher.remaining, r.isFinite, r > 1 {
            let f = DateComponentsFormatter()
            f.allowedUnits = r >= 3600 ? [.hour, .minute] : [.minute, .second]
            f.unitsStyle = .abbreviated
            parts.append("encore \(f.string(from: r) ?? "")")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Fin

struct EndView: View {
    let happy: Bool
    let title: String
    let message: String
    let again: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Mascot(mood: happy ? .happy : .sad, size: 92)
            Text(title).font(Theme.title(28))
            Text(message).font(.system(size: 14)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 460)
            Spacer()
            Button(happy ? "Flasher une autre clé" : "Recommencer", action: again).buttonStyle(PillButton(filled: true))
                .keyboardShortcut(.defaultAction)
        }
    }
}
